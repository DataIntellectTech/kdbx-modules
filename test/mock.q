/ framework for mocking variables

.test.mocks:1!enlist`name`existed`orig!(`;0b;"");

/ mocks a variable
.test.mock:{[name;mockval]
  if[not name in key .test.mocks;
    .test.mocks[name;`existed`orig]:@[{(1b;get x)};name;{(0b;::)}]];
  name set mockval;
  };

/ unmocks (i.e. restores) original variable value
/ if the variable previously didn't exist, it's simply deleted
.test.unmock:{[nm]
  if[1=count .test.mocks;:()]; / only sentinel row
  t:0!$[nm~(::);1_.test.mocks;select from .test.mocks where name in nm];
  .test.deletefromns each exec name from t where not existed;
  exec name set'orig from t where existed;
  .test.mocks:(select name from t)_.test.mocks;
  };

/ internal - deletes an object from the namespace it belongs to
.test.deletefromns:{[obj]
  if[obj like".z.*";:system"x ",string obj]; / Special .z callbacks
  split:` vs obj;
  k:last obj;
  ns:$[1=count split;`.;` sv -1_split];
  ![ns;();0b;enlist k];
  }
